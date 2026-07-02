import Foundation
import NIO
import NIOHTTP1
import Testing

@testable import Toolsmith

@Suite("HTTPServer")
struct HTTPServerTests {
    private func makeServer() -> (HTTPServer, ServerRouter) {
        var router = ServerRouter()
        router.register(.GET, "/status") { _ in
            .json(Data(#"{"name":"toolsmith","status":"ok"}"#.utf8))
        }
        router.register(.GET, "/echo-headers") { request in
            let value = request.headers.first(where: { $0.0.caseInsensitiveCompare("x-test") == .orderedSame })?.1 ?? ""
            return .text(value)
        }
        router.register(.POST, "/echo-body") { request in
            .json(request.body)
        }
        router.register(.GET, "/stream") { _ in
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                continuation.yield(Data("event: message\ndata: one\n\n".utf8))
                continuation.yield(Data("event: message\ndata: two\n\n".utf8))
                continuation.yield(Data("event: message\ndata: three\n\n".utf8))
                continuation.finish()
            }
            return ServerHTTPResponse(
                status: .ok,
                headers: [("Content-Type", "text/event-stream")],
                body: .stream(stream)
            )
        }
        let server = HTTPServer(router: router)
        return (server, router)
    }

    private func get(_ url: URL, headers: [(String, String)] = []) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (k, v) in headers { request.addValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (status, data)
    }

    private func post(_ url: URL, body: Data) async throws -> (Int, Data) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private func baseURL(_ address: SocketAddress) -> URL {
        URL(string: "http://127.0.0.1:\(address.port!)")!
    }

    @Test("stop() tears down cleanly with an open streaming response", .timeLimit(.minutes(1)))
    func teardownWithOpenStream() async throws {
        var router = ServerRouter()
        router.register(.GET, "/hang") { _ in
            // A parked SSE stream: one chunk, then never finishes — the
            // shape that left an outstanding write promise and made
            // group.shutdownGracefully() trap on "leaking promise".
            let stream = AsyncThrowingStream<Data, Error> { continuation in
                continuation.yield(Data(": open\n\n".utf8))
            }
            return ServerHTTPResponse(
                status: .ok,
                headers: [("Content-Type", "text/event-stream")],
                body: .stream(stream)
            )
        }
        let server = HTTPServer(router: router)
        let address = try await server.start(host: "127.0.0.1", port: 0)

        // Open the stream and read the first chunk so the connection is
        // established and the response is mid-flight when we tear down.
        let (bytes, response) = try await URLSession.shared.bytes(
            from: URL(string: "http://127.0.0.1:\(address.port!)/hang")!
        )
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        var iterator = bytes.lines.makeAsyncIterator()
        _ = try? await iterator.next()

        // Must complete without trapping on a leaked promise.
        try await server.stop()
    }

    @Test("GET /status returns a JSON 200")
    func statusRoute() async throws {
        let (server, _) = makeServer()
        let address = try await server.start(host: "127.0.0.1", port: 0)
        defer { Task { try? await server.stop() } }

        let (status, data) = try await get(baseURL(address).appendingPathComponent("status"))
        #expect(status == 200)
        #expect(String(decoding: data, as: UTF8.self).contains(#""status":"ok""#))
    }

    @Test("Unknown path returns 404")
    func notFound() async throws {
        let (server, _) = makeServer()
        let address = try await server.start(host: "127.0.0.1", port: 0)
        defer { Task { try? await server.stop() } }

        let (status, _) = try await get(baseURL(address).appendingPathComponent("nowhere"))
        #expect(status == 404)
    }

    @Test("Wrong method on a known path returns 405")
    func methodNotAllowed() async throws {
        let (server, _) = makeServer()
        let address = try await server.start(host: "127.0.0.1", port: 0)
        defer { Task { try? await server.stop() } }

        let (status, _) = try await post(baseURL(address).appendingPathComponent("status"), body: Data())
        #expect(status == 405)
    }

    @Test("Request headers reach the handler")
    func headersFlowThrough() async throws {
        let (server, _) = makeServer()
        let address = try await server.start(host: "127.0.0.1", port: 0)
        defer { Task { try? await server.stop() } }

        let (status, data) = try await get(
            baseURL(address).appendingPathComponent("echo-headers"),
            headers: [("X-Test", "hi-there")]
        )
        #expect(status == 200)
        #expect(String(decoding: data, as: UTF8.self) == "hi-there")
    }

    @Test("POST body is forwarded to the handler")
    func bodyForwarded() async throws {
        let (server, _) = makeServer()
        let address = try await server.start(host: "127.0.0.1", port: 0)
        defer { Task { try? await server.stop() } }

        let body = Data(#"{"k":"v"}"#.utf8)
        let (status, data) = try await post(baseURL(address).appendingPathComponent("echo-body"), body: body)
        #expect(status == 200)
        #expect(data == body)
    }

    @Test("Streaming response is delivered as SSE")
    func streamingResponse() async throws {
        let (server, _) = makeServer()
        let address = try await server.start(host: "127.0.0.1", port: 0)
        defer { Task { try? await server.stop() } }

        var request = URLRequest(url: baseURL(address).appendingPathComponent("stream"))
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        #expect(http?.statusCode == 200)
        #expect((http?.value(forHTTPHeaderField: "Content-Type") ?? "").contains("text/event-stream"))

        var parser = SSEParser()
        let events = parser.feed(text: String(decoding: data, as: UTF8.self))
        #expect(events.map(\.data) == ["one", "two", "three"])
    }
}
